defmodule Arena.Map.Gm.CharEdit do
  @moduledoc "GM character editing commands: give items, edit stats, rename, revive, etc."

  alias Arena.AuditLog
  alias Arena.Map.Helpers
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
              Helpers.send_inventory_slot(state.sessions, target_id, new_inventory, slot)
              AuditLog.log_gm_action(char_id, "give_item", "#{amount}x #{item_id} to #{target.name}")
              Helpers.gm_console(state, char_id, "Gave #{amount}x item #{item_id} to #{target.name}.")
              {:noreply, state}

            {:gold, gold_amount} ->
              target = %{target | gold: target.gold + gold_amount}
              players = Map.put(state.players, target_id, target)
              state = %{state | players: players}

              Helpers.send_to_session(
                state.sessions,
                target_id,
                {:send_raw, Encoder.encode({:update_gold, %{gold: target.gold}})}
              )

              AuditLog.log_gm_action(char_id, "give_gold", "#{gold_amount} to #{target.name}")
              Helpers.gm_console(state, char_id, "Gave #{gold_amount} gold to #{target.name}.")
              {:noreply, state}

            {:error, :inventory_full} ->
              Helpers.gm_console(state, char_id, "#{target.name}'s inventory is full.")
              {:noreply, state}
          end

        :not_found ->
          Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
          {:noreply, state}
      end
    else
      _ ->
        Helpers.gm_console(state, char_id, "Usage: /GIVEITEM name item_id amount")
        {:noreply, state}
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

            Helpers.send_to_session(
              state.sessions,
              target_id,
              {:send_raw, Encoder.encode({:update_gold, %{gold: target.gold}})}
            )

            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=gold value=#{target.gold}")
            Helpers.gm_console(state, char_id, "Set #{target.name} gold to #{target.gold}.")
            {:noreply, state}

          {"2", {value, _}} ->
            target = %{target | level: max(min(value, 50), 1)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=level value=#{target.level}")
            Helpers.gm_console(state, char_id, "Set #{target.name} level to #{target.level}.")
            {:noreply, state}

          {"3", {value, _}} ->
            target = %{target | xp: max(value, 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}
            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=xp value=#{target.xp}")
            Helpers.gm_console(state, char_id, "Set #{target.name} XP to #{target.xp}.")
            {:noreply, state}

          {"4", {value, _}} ->
            target = %{target | hp: max(min(value, target.max_hp), 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              target_id,
              {:send_raw, Encoder.encode({:update_hp, %{min_hp: target.hp, shield: 0}})}
            )

            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=hp value=#{target.hp}")
            Helpers.gm_console(state, char_id, "Set #{target.name} HP to #{target.hp}.")
            {:noreply, state}

          {"5", {value, _}} ->
            target = %{target | mana: max(min(value, target.max_mana), 0)}
            players = Map.put(state.players, target_id, target)
            state = %{state | players: players}

            Helpers.send_to_session(
              state.sessions,
              target_id,
              {:send_raw, Encoder.encode({:update_mana, %{min_mana: target.mana}})}
            )

            AuditLog.log_gm_action(char_id, "edit_char", "#{target.name} option=mana value=#{target.mana}")
            Helpers.gm_console(state, char_id, "Set #{target.name} mana to #{target.mana}.")
            {:noreply, state}

          _ ->
            Helpers.gm_console(state, char_id, "Usage: /EDITCHAR name option value")
            Helpers.gm_console(state, char_id, "Options: 1=Gold 2=Level 3=XP 4=HP 5=Mana")
            {:noreply, state}
        end

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_alter_name(state, char_id, old_name, new_name) do
    case Helpers.find_player_by_name(state, old_name) do
      {:ok, target_id, target} ->
        target = %{target | name: new_name}
        players = Map.put(state.players, target_id, target)
        state = %{state | players: players}
        Helpers.broadcast_character_change(state, target)
        AuditLog.log_gm_action(char_id, "alter_name", "#{old_name} -> #{new_name}")
        Helpers.gm_console(state, char_id, "Renamed #{old_name} to #{new_name}.")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{old_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_revive(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        if not target.dead do
          Helpers.gm_console(state, char_id, "#{target.name} no esta muerto.")
          {:noreply, state}
        else
          target = %{target | dead: false, hp: target.max_hp}
          players = Map.put(state.players, target_id, target)
          state = %{state | players: players}

          Helpers.send_to_session(
            state.sessions,
            target_id,
            {:send_raw, Encoder.encode({:update_hp, %{min_hp: target.hp}})}
          )

          Helpers.send_to_session(
            state.sessions,
            target_id,
            {:send_raw,
             Encoder.encode(
               {:console_msg, %{message: "Un GM te ha resucitado.", font_index: 0}}
             )}
          )

          Helpers.broadcast_character_change(state, target)
          AuditLog.log_gm_action(char_id, "revive", target.name)
          Helpers.gm_console(state, char_id, "#{target.name} ha sido resucitado.")
          {:noreply, state}
        end

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_show_name(state, char_id, entity) do
    show = !Map.get(entity, :show_name, true)
    entity = Map.put(entity, :show_name, show)
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}
    status = if show, do: "visible", else: "hidden"
    AuditLog.log_gm_action(char_id, "show_name", status)
    Helpers.gm_console(state, char_id, "Name #{status}.")
    {:noreply, state}
  end

  def gm_set_description(state, char_id, entity, desc) do
    entity = Map.put(entity, :description, desc)
    players = Map.put(state.players, char_id, entity)
    state = %{state | players: players}
    AuditLog.log_gm_action(char_id, "set_description", desc)
    Helpers.gm_console(state, char_id, "Description set to: #{desc}")
    {:noreply, state}
  end

  def gm_set_speed(state, char_id, entity, speed_str) do
    case Float.parse(speed_str) do
      {speed, _} ->
        entity = Map.put(entity, :speed_mod, speed)
        players = Map.put(state.players, char_id, entity)
        state = %{state | players: players}
        AuditLog.log_gm_action(char_id, "set_speed", "#{speed}")
        Helpers.gm_console(state, char_id, "Speed set to #{speed}.")
        {:noreply, state}

      :error ->
        Helpers.gm_console(state, char_id, "Invalid speed value.")
        {:noreply, state}
    end
  end
end
