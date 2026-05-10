defmodule Arena.Map.Gm.CharEdit do
  @moduledoc """
  GM character editing commands: give items, edit stats, rename, revive, etc.

  Public handlers follow the effects contract `{:ok, state, effects}`.
  GM updates that mutate a target player typically emit two console
  packets: one to the target (the stat stream / "Un GM te ha resucitado"
  notice) and one to the GM (audit / confirmation). Audit logging via
  `Arena.AuditLog.log_gm_action/3` runs as a pre-effect side-effect so it
  always logs regardless of whether the caller drains the effect list.

  The MapServer dispatch path is `GmCommands.dispatch_gm_command` which
  wraps each CharEdit call in `Effects.run_handler/2` to translate the
  `{:ok, state, effects}` tuple into the legacy `{:noreply, state}` the
  chat handler expects.
  """

  alias Arena.AuditLog
  alias Arena.Data.GameData
  alias Arena.Map.{Effects, Helpers}
  alias AoProtocol.Server.Encoder

  def gm_give_item(state, char_id, target_name, item_str, amount_str) do
    with {item_id, ""} <- Integer.parse(item_str),
         {amount, ""} <- Integer.parse(amount_str),
         true <- amount > 0 do
      case Helpers.find_player_by_name(state, target_name) do
        {:ok, target_id, target} ->
          case Arena.Inventory.add_item(target.inventory, item_id, amount) do
            {:ok, new_inventory, slot} ->
              target = %{target | inventory: new_inventory}
              players = Map.put(state.players, target_id, target)
              state = %{state | players: players}
              AuditLog.log_gm_action(char_id, "give_item", "#{amount}x #{item_id} to #{target.name}")

              effects = [
                Effects.send(target_id, inventory_slot_packet(new_inventory, slot)),
                console_effect(char_id, "Gave #{amount}x item #{item_id} to #{target.name}.")
              ]

              {:ok, state, effects}

            {:gold, gold_amount} ->
              target = %{target | gold: target.gold + gold_amount}
              players = Map.put(state.players, target_id, target)
              state = %{state | players: players}

              AuditLog.log_gm_action(char_id, "give_gold", "#{gold_amount} to #{target.name}")

              effects = [
                Effects.send(target_id, Encoder.encode({:update_gold, %{gold: target.gold}})),
                console_effect(char_id, "Gave #{gold_amount} gold to #{target.name}.")
              ]

              {:ok, state, effects}

            {:error, :inventory_full} ->
              {:ok, state,
               [console_effect(char_id, "#{target.name}'s inventory is full.")]}
          end

        :not_found ->
          {:ok, state,
           [console_effect(char_id, "Player '#{target_name}' not found on this map.")]}
      end
    else
      _ ->
        {:ok, state, [console_effect(char_id, "Usage: /GIVEITEM name item_id amount")]}
    end
  end

  def gm_edit_char(state, char_id, target_name, option_str, value_str) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        case {option_str, Integer.parse(value_str)} do
          {"1", {value, _}} ->
            target = %{target | gold: max(value, 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=gold value=#{target.gold}")

            effects = [
              Effects.send(target_id, Encoder.encode({:update_gold, %{gold: target.gold}})),
              console_effect(char_id, "Set #{target.name} gold to #{target.gold}.")
            ]

            {:ok, state, effects}

          {"2", {value, _}} ->
            target = %{target | level: max(min(value, 50), 1)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=level value=#{target.level}")

            {:ok, state,
             [console_effect(char_id, "Set #{target.name} level to #{target.level}.")]}

          {"3", {value, _}} ->
            target = %{target | xp: max(value, 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=xp value=#{target.xp}")

            {:ok, state, [console_effect(char_id, "Set #{target.name} XP to #{target.xp}.")]}

          {"4", {value, _}} ->
            target = %{target | hp: max(min(value, target.max_hp), 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=hp value=#{target.hp}")

            effects = [
              Effects.send(
                target_id,
                Encoder.encode({:update_hp, %{min_hp: target.hp, shield: 0}})
              ),
              console_effect(char_id, "Set #{target.name} HP to #{target.hp}.")
            ]

            {:ok, state, effects}

          {"5", {value, _}} ->
            target = %{target | mana: max(min(value, target.max_mana), 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=mana value=#{target.mana}")

            effects = [
              Effects.send(
                target_id,
                Encoder.encode({:update_mana, %{min_mana: target.mana}})
              ),
              console_effect(char_id, "Set #{target.name} mana to #{target.mana}.")
            ]

            {:ok, state, effects}

          _ ->
            effects = [
              console_effect(char_id, "Usage: /EDITCHAR name option value"),
              console_effect(char_id, "Options: 1=Gold 2=Level 3=XP 4=HP 5=Mana")
            ]

            {:ok, state, effects}
        end

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end

  def gm_alter_name(state, char_id, old_name, new_name) do
    case Helpers.find_player_by_name(state, old_name) do
      {:ok, target_id, target} ->
        target = %{target | name: new_name}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        AuditLog.log_gm_action(char_id, "alter_name", "#{old_name} -> #{new_name}")

        effects = [
          Effects.broadcast_character_change(target),
          console_effect(char_id, "Renamed #{old_name} to #{new_name}.")
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{old_name}' not found.")]}
    end
  end

  def gm_revive(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        if not target.dead do
          {:ok, state, [console_effect(char_id, "#{target.name} no esta muerto.")]}
        else
          target = %{target | dead: false, hp: target.max_hp}
          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}
          AuditLog.log_gm_action(char_id, "revive", target.name)

          effects = [
            Effects.send(target_id, Encoder.encode({:update_hp, %{min_hp: target.hp}})),
            Effects.send(target_id, console_packet("Un GM te ha resucitado.")),
            Effects.broadcast_character_change(target),
            console_effect(char_id, "#{target.name} ha sido resucitado.")
          ]

          {:ok, state, effects}
        end

      :not_found ->
        {:ok, state,
         [console_effect(char_id, "Player '#{target_name}' not found on this map.")]}
    end
  end

  def gm_show_name(state, char_id, entity) do
    show = !Map.get(entity, :show_name, true)
    entity = Map.put(entity, :show_name, show)
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}
    status = if show, do: "visible", else: "hidden"
    AuditLog.log_gm_action(char_id, "show_name", status)

    {:ok, state, [console_effect(char_id, "Name #{status}.")]}
  end

  def gm_set_description(state, char_id, entity, desc) do
    entity = Map.put(entity, :description, desc)
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}
    AuditLog.log_gm_action(char_id, "set_description", desc)

    {:ok, state, [console_effect(char_id, "Description set to: #{desc}")]}
  end

  def gm_set_speed(state, char_id, entity, speed_str) do
    case Float.parse(speed_str) do
      {speed, _} ->
        entity = Map.put(entity, :speed_mod, speed)
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        AuditLog.log_gm_action(char_id, "set_speed", "#{speed}")

        {:ok, state, [console_effect(char_id, "Speed set to #{speed}.")]}

      :error ->
        {:ok, state, [console_effect(char_id, "Invalid speed value.")]}
    end
  end

  # ── VB6 shortcut commands ──────────────────────────────────────────────

  @doc "/SETBODY target body_id — change a player's body graphic (VB6 parity)."
  def gm_set_body(state, char_id, target_name, body_str) do
    case Integer.parse(body_str) do
      {body_id, ""} ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, target_id, target} ->
            target = %{target | body_id: body_id}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "set_body", "#{target.name} body=#{body_id}")

            effects = [
              Effects.broadcast_character_change(target),
              console_effect(char_id, "Set #{target.name} body to #{body_id}.")
            ]

            {:ok, state, effects}

          :not_found ->
            {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
        end

      _ ->
        {:ok, state, [console_effect(char_id, "Usage: /SETBODY name body_id")]}
    end
  end

  @doc "/SETHEAD target head_id — change a player's head graphic (VB6 parity)."
  def gm_set_head(state, char_id, target_name, head_str) do
    case Integer.parse(head_str) do
      {head_id, ""} ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, target_id, target} ->
            target = %{target | head_id: head_id}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "set_head", "#{target.name} head=#{head_id}")

            effects = [
              Effects.broadcast_character_change(target),
              console_effect(char_id, "Set #{target.name} head to #{head_id}.")
            ]

            {:ok, state, effects}

          :not_found ->
            {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
        end

      _ ->
        {:ok, state, [console_effect(char_id, "Usage: /SETHEAD name head_id")]}
    end
  end

  @doc "/SETGOLD target amount — shortcut to set a player's gold (VB6 parity)."
  def gm_set_gold(state, char_id, target_name, gold_str) do
    case Integer.parse(gold_str) do
      {value, _} ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, target_id, target} ->
            target = %{target | gold: max(value, 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "set_gold", "#{target.name} gold=#{target.gold}")

            effects = [
              Effects.send(target_id, Encoder.encode({:update_gold, %{gold: target.gold}})),
              console_effect(char_id, "Set #{target.name} gold to #{target.gold}.")
            ]

            {:ok, state, effects}

          :not_found ->
            {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
        end

      :error ->
        {:ok, state, [console_effect(char_id, "Usage: /SETGOLD name amount")]}
    end
  end

  @doc "/SETLEVEL target level — shortcut to set a player's level (VB6 parity)."
  def gm_set_level(state, char_id, target_name, level_str) do
    case Integer.parse(level_str) do
      {value, _} ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, target_id, target} ->
            target = %{target | level: max(min(value, 50), 1)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "set_level", "#{target.name} level=#{target.level}")

            {:ok, state,
             [console_effect(char_id, "Set #{target.name} level to #{target.level}.")]}

          :not_found ->
            {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
        end

      :error ->
        {:ok, state, [console_effect(char_id, "Usage: /SETLEVEL name level")]}
    end
  end

  @doc "/SETSKILL target skill_name value — set a player's skill value (VB6 parity)."
  def gm_set_skill(state, char_id, target_name, skill_name, value_str) do
    case Integer.parse(value_str) do
      {value, _} ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, target_id, target} ->
            clamped = max(min(value, 100), 0)
            skill_atom = String.to_existing_atom(skill_name)
            new_skills = Map.put(target.skills, skill_atom, clamped)
            target = %{target | skills: new_skills}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "set_skill", "#{target.name} #{skill_name}=#{clamped}")

            {:ok, state,
             [console_effect(char_id, "Set #{target.name} #{skill_name} to #{clamped}.")]}

          :not_found ->
            {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
        end

      :error ->
        {:ok, state, [console_effect(char_id, "Usage: /SETSKILL name skill_name value")]}
    end
  end

  ## Internal helpers ────────────────────────────────────────────────────

  defp console_packet(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  defp console_effect(char_id, message) do
    Effects.send(char_id, console_packet(message))
  end

  # Mirror of `Helpers.send_inventory_slot/4` packet construction (sans
  # transmission). Inlined here so reward effects can be constructed without
  # going through the legacy `{:send_raw, _}` shim.
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
end
