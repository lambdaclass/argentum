defmodule Arena.Map.Gm.Inspection do
  @moduledoc "GM inspection commands: info, stats, gold, inventory, bank, skills, locate, etc."

  alias Arena.Map.Helpers
  alias Arena.Data.GameData

  def gm_info(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        Helpers.gm_console(state, char_id, "=== Player Info: #{target.name} ===")
        Helpers.gm_console(state, char_id, "HP: #{target.hp}/#{target.max_hp} | Mana: #{target.mana}/#{target.max_mana}")
        Helpers.gm_console(state, char_id, "Level: #{target.level} | Class: #{target.class} | Race: #{target.race}")
        Helpers.gm_console(state, char_id, "Position: map #{target.map_id} (#{target.x}, #{target.y})")
        Helpers.gm_console(state, char_id, "Gold: #{target.gold} | XP: #{target.xp}")

        Helpers.gm_console(
          state,
          char_id,
          "Dead: #{target.dead} | Criminal: #{target.criminal} | Invisible: #{target.invisible}"
        )

        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found on this map.")
        {:noreply, state}
    end
  end

  def gm_char_stats(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        Helpers.gm_console(state, char_id, "=== Stats: #{target.name} ===")
        Helpers.gm_console(state, char_id, "STR: #{target.str} AGI: #{target.agi} INT: #{target.int}")
        Helpers.gm_console(state, char_id, "CON: #{target.con} CHA: #{target.cha}")
        Helpers.gm_console(state, char_id, "Level: #{target.level} XP: #{target.xp}")
        Helpers.gm_console(state, char_id, "HP: #{target.hp}/#{target.max_hp} Mana: #{target.mana}/#{target.max_mana}")
        Helpers.gm_console(state, char_id, "Stamina: #{target.stamina}/#{target.max_stamina}")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_char_gold(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        Helpers.gm_console(state, char_id, "#{target.name} gold: #{target.gold}")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_char_inventory(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        Helpers.gm_console(state, char_id, "=== Inventory: #{target.name} ===")

        target.inventory
        |> Enum.with_index(1)
        |> Enum.each(fn {item, slot} ->
          if item != nil do
            item_def = GameData.get_item(item.item_id)
            name = if item_def, do: item_def.name, else: "?"
            Helpers.gm_console(state, char_id, "Slot #{slot}: #{name} (#{item.item_id}) x#{item.amount}")
          end
        end)

        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_char_bank(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        Helpers.gm_console(state, char_id, "#{target.name} bank gold: #{Map.get(target, :bank_gold, 0)}")
        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_char_skills(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        Helpers.gm_console(state, char_id, "=== Skills: #{target.name} ===")

        Enum.each(target.skills, fn {skill, level} ->
          Helpers.gm_console(state, char_id, "#{skill}: #{level}")
        end)

        {:noreply, state}

      :not_found ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}
    end
  end

  def gm_locate(state, char_id, target_name) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, _target_char_id, info} ->
        Helpers.gm_console(state, char_id, "#{target_name} está en mapa #{info.map_id}")
        {:noreply, state}

      :not_found ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, _target_id, target} ->
            Helpers.gm_console(state, char_id, "#{target.name} está en mapa #{state.map_id} (#{target.x}, #{target.y})")
            {:noreply, state}

          :not_found ->
            Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
            {:noreply, state}
        end
    end
  end

  def gm_online_map(state, char_id) do
    names = Enum.map(state.players, fn {_id, entity} -> entity.name end)
    count = length(names)
    Helpers.gm_console(state, char_id, "Jugadores en mapa (#{count}): #{Enum.join(names, ", ")}")
    {:noreply, state}
  end

  def gm_check_slot(state, char_id, target_name, slot_str) do
    case {Helpers.find_player_by_name(state, target_name), Integer.parse(slot_str)} do
      {{:ok, _target_id, target}, {slot, _}} when slot >= 1 ->
        inventory = Map.get(target, :inventory, %{})

        case Map.get(inventory, slot) do
          nil ->
            Helpers.gm_console(state, char_id, "#{target.name} slot #{slot}: (empty)")

          item ->
            item_def = GameData.get_item(item.item_id)
            name = if item_def, do: item_def.name, else: "?"
            Helpers.gm_console(state, char_id, "#{target.name} slot #{slot}: #{name} (#{item.item_id}) x#{item.amount}")
        end

        {:noreply, state}

      {:not_found, _} ->
        Helpers.gm_console(state, char_id, "Player '#{target_name}' not found.")
        {:noreply, state}

      _ ->
        Helpers.gm_console(state, char_id, "Invalid slot.")
        {:noreply, state}
    end
  end

  def gm_creatures_in_map(state, char_id, map_str) do
    case Integer.parse(map_str) do
      {map_id, ""} ->
        if map_id == state.map_id do
          gm_spawn_list(state, char_id)
        else
          Helpers.gm_console(state, char_id, "Cross-map NPC queries are not supported yet.")
          {:noreply, state}
        end

      _ ->
        Helpers.gm_console(state, char_id, "Usage: /CREATURES map_id")
        {:noreply, state}
    end
  end

  def gm_spawn_list(state, char_id) do
    entries =
      Enum.filter(state.npcs_live, fn {_inst_id, npc} -> npc.alive end)
      |> Enum.map(fn {inst_id, npc} ->
        npc_def = GameData.get_npc(npc.npc_id)
        name = if npc_def, do: npc_def.name, else: "?"
        "#{inst_id}: #{name} (#{npc.npc_id}) at (#{npc.x},#{npc.y})"
      end)

    Helpers.gm_console(state, char_id, "NPCs on map (#{length(entries)}):")

    Enum.each(entries, fn entry ->
      Helpers.gm_console(state, char_id, entry)
    end)

    {:noreply, state}
  end
end
