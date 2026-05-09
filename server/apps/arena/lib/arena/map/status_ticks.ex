defmodule Arena.Map.StatusTicks do
  @moduledoc "Buff expiry, regen, hunger/thirst, and penalty ticks."

  alias Arena.Map.{Effects, Helpers}
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

  @doc """
  Tick one player's buff list.

  Returns `{state, effects}` where `effects` is the list of
  `Arena.Map.Effect.t()` produced by this tick (status-clear packets,
  poison damage, death side-effects, invisibility reveal, character
  change). Caller (`MapServer.handle_info(:buff_tick, ...)`) collects
  effects across all players and runs them through `Effects.run/2` once.

  VB6 emission order, preserved here:
    1. `paralize_ok` / `blind_no_more` / `dumb_no_more` on flag clear.
    2. Per active poison buff that ticks: `update_hp` then poison
       console message.
    3. On poison kill: "Has muerto!" console + PlayerDeath effects.
    4. `reveal_to_non_gm` if invisibility just expired.
    5. `broadcast_character_change` if the player just died.
  """
  @spec process_player_buffs(map(), term(), map(), integer()) ::
          {map(), [Arena.Map.Effect.t()]}
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

    # VB6: status-clear packets — let the client exit the frozen/blind/silenced
    # overlays. WriteParalizeOK / WriteBlindNoMore / WriteDumbNoMore.
    clear_effects =
      [] ++
        if(was_paralyzed and not entity.paralyzed,
          do: [Effects.send(char_id, Encoder.encode({:paralize_ok, %{}}))],
          else: []
        ) ++
        if(was_blind and not entity.blind,
          do: [Effects.send(char_id, Encoder.encode({:blind_no_more, %{}}))],
          else: []
        ) ++
        if(was_dumb and not entity.dumb,
          do: [Effects.send(char_id, Encoder.encode({:dumb_no_more, %{}}))],
          else: []
        )

    # Process poison ticks on active poison buffs. Reduce builds the new
    # buff list and the poison effects list in one pass.
    {active_rev, entity, poison_effects_rev} =
      Enum.reduce(active, {[], entity, []}, fn buff, {bacc, ent, eacc} ->
        if buff.type == :poisoned and now >= (buff[:next_tick] || 0) do
          damage = max(Enum.random(3..5) * div(ent.max_hp, 100), 1)
          new_hp = max(ent.hp - damage, 0)
          ent = %{ent | hp: new_hp}

          eacc = [
            Effects.send(
              char_id,
              Encoder.encode(
                {:console_msg, %{message: "Veneno te hace #{damage} de daño.", font_index: 5}}
              )
            ),
            Effects.send(char_id, Encoder.encode({:update_hp, %{min_hp: new_hp}}))
            | eacc
          ]

          buff = %{buff | next_tick: now + @poison_tick_interval}
          {[buff | bacc], ent, eacc}
        else
          {[buff | bacc], ent, eacc}
        end
      end)

    active = Enum.reverse(active_rev)
    poison_effects = Enum.reverse(poison_effects_rev)

    entity = %{entity | buffs: active}

    # Poison death (HP fell to 0 this tick)
    was_alive = not entity.dead

    {entity, state, death_effects} =
      if entity.hp <= 0 and was_alive do
        death_console =
          Effects.send(
            char_id,
            Encoder.encode({:console_msg, %{message: "Has muerto!", font_index: 5}})
          )

        {entity, state, pd_effects} =
          Arena.Map.PlayerDeath.handle_player_death(state, char_id, entity)

        {entity, state, [death_console | pd_effects]}
      else
        {entity, state, []}
      end

    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}

    # Reveal player if invisibility just expired
    reveal_effects =
      if was_invisible and not entity.invisible do
        [Effects.reveal_to_non_gm(entity)]
      else
        []
      end

    # Broadcast character_change on poison death (everyone needs to see the corpse)
    death_broadcast =
      if was_alive and entity.dead do
        [Effects.broadcast_character_change(entity)]
      else
        []
      end

    effects = clear_effects ++ poison_effects ++ death_effects ++ reveal_effects ++ death_broadcast
    {state, effects}
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

  @doc """
  Tick hunger/thirst, regen, oculto timers, and starvation across every
  living player on the map.

  Returns `{state, effects}` where `effects` is the merged list of
  `Arena.Map.Effect.t()` produced by every player processed this tick
  (vitals streams, rest/meditate-completion consoles, oculto-expiry
  console + reveal, starvation death console + character_change, plus
  any PlayerDeath effects on starvation-kill). The caller
  (`MapServer.handle_info(:regen_tick, ...)`) runs them through
  `Effects.run/2` once.
  """
  @spec process_regen_tick(map()) :: {map(), [Arena.Map.Effect.t()]}
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

    Enum.reduce(state.players, {state, []}, fn {char_id, entity}, {state, eacc} ->
      if entity.dead do
        {state, eacc}
      else
        {state, effects} =
          regen_one_player(state, char_id, entity, drain_thirst?, drain_hunger?, decrement_penalty?)

        {state, eacc ++ effects}
      end
    end)
  end

  defp regen_one_player(state, char_id, entity, drain_thirst?, drain_hunger?, decrement_penalty?) do
    original_entity = state.players[char_id]
    was_invisible_before_regen = entity.invisible
    effects = []

    # VB6: decrement jail penalty every minute
    entity =
      if decrement_penalty? and entity.penalty > 0 do
        %{entity | penalty: entity.penalty - 1}
      else
        entity
      end

    # Decrement oculto timer; when it reaches 0, break oculto.
    # Exception: hunters with 100% hiding skill + camo armor stay hidden.
    {entity, effects} =
      if entity.oculto and entity.oculto_timer > 0 do
        hiding_skill = Map.get(entity.skills, :hiding, 0)
        armor_id = entity.equipment[:armor]
        armor_def = if armor_id, do: GameData.get_item(armor_id)
        has_camo = armor_def != nil and armor_def.obj_type == 43

        if hiding_skill >= 100 and has_camo do
          {entity, effects}
        else
          new_timer = entity.oculto_timer - 1

          if new_timer <= 0 do
            console =
              Effects.send(
                char_id,
                Encoder.encode(
                  {:console_msg, %{message: "Has vuelto a ser visible.", font_index: 0}}
                )
              )

            {%{entity | oculto: false, oculto_timer: 0, invisible: false}, effects ++ [console]}
          else
            {%{entity | oculto_timer: new_timer}, effects}
          end
        end
      else
        {entity, effects}
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
    {entity, state, effects} =
      if entity.hp <= 0 and not entity.dead do
        {entity, state, pd_effects} =
          Arena.Map.PlayerDeath.handle_player_death(state, char_id, %{entity | hp: 0})

        {entity, state, effects ++ pd_effects}
      else
        {entity, state, effects}
      end

    # Regen (blocked by starvation/dehydration)
    {entity, effects} =
      cond do
        starving or dehydrated ->
          {entity, effects}

        entity.resting and entity.hp < entity.max_hp ->
          # VB6: rest regen = con / 6, min 1
          regen = max(div(entity.con, 6), 1)
          new_hp = min(entity.hp + regen, entity.max_hp)
          entity = %{entity | hp: new_hp}

          if new_hp >= entity.max_hp do
            console =
              Effects.send(
                char_id,
                Encoder.encode(
                  {:console_msg, %{message: "Has terminado de descansar.", font_index: 0}}
                )
              )

            {%{entity | resting: false}, effects ++ [console]}
          else
            {entity, effects}
          end

        entity.meditating and entity.mana < entity.max_mana ->
          # VB6: meditate regen = int * meditation_skill / 35, min 1
          med_skill = Map.get(entity.skills, :meditation, 0)
          regen = max(div(entity.int * max(med_skill, 1), 35), 1)
          new_mana = min(entity.mana + regen, entity.max_mana)
          entity = %{entity | mana: new_mana}

          if new_mana >= entity.max_mana do
            console =
              Effects.send(
                char_id,
                Encoder.encode(
                  {:console_msg, %{message: "Has terminado de meditar.", font_index: 0}}
                )
              )

            {%{entity | meditating: false}, effects ++ [console]}
          else
            {entity, effects}
          end

        true ->
          {entity, effects}
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

    # Vitals streams
    effects =
      if vitals_changed do
        effects ++
          [
            Effects.send(
              char_id,
              Encoder.encode(
                {:update_hunger_and_thirst,
                 %{
                   max_hunger: 100,
                   min_hunger: entity.hunger,
                   max_thirst: 100,
                   min_thirst: entity.thirst
                 }}
              )
            )
          ]
      else
        effects
      end

    effects =
      if hp_changed or entity.hp != original_entity.hp do
        effects ++
          [Effects.send(char_id, Encoder.encode({:update_hp, %{min_hp: entity.hp, shield: 0}}))]
      else
        effects
      end

    effects =
      if entity.mana != original_entity.mana do
        effects ++
          [Effects.send(char_id, Encoder.encode({:update_mana, %{min_mana: entity.mana}}))]
      else
        effects
      end

    effects =
      if stamina_changed or entity.stamina != original_entity.stamina do
        effects ++
          [Effects.send(char_id, Encoder.encode({:update_stamina, %{min_sta: entity.stamina}}))]
      else
        effects
      end

    {state, effects} =
      if entity.dead and not original_entity.dead do
        starve_console =
          Effects.send(
            char_id,
            Encoder.encode(
              {:console_msg, %{message: "Has muerto de inanición.", font_index: 0}}
            )
          )

        state = %{state | players: Map.put(state.players, char_id, entity)}

        {state,
         effects ++ [starve_console, Effects.broadcast_character_change(entity)]}
      else
        {%{state | players: Map.put(state.players, char_id, entity)}, effects}
      end

    # Reveal player if oculto/invisible just expired during this tick
    effects =
      if was_invisible_before_regen and not entity.invisible do
        effects ++ [Effects.reveal_to_non_gm(entity)]
      else
        effects
      end

    {state, effects}
  end
end
