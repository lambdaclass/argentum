defmodule Arena.Map.Gm.Inspection do
  @moduledoc """
  GM inspection commands: info, stats, gold, inventory, bank, skills,
  locate, etc.

  Public handlers return `{:ok, state, [Effect.t()]}`. Inspection
  commands are pure reads — they don't mutate state and don't have
  audit-log side effects. Each handler builds the list of console
  packets sent to the GM and threads it through the effects runner.
  """

  alias Arena.Data.GameData
  alias Arena.Map.{Effects, Helpers}
  alias AoProtocol.Server.Encoder

  def gm_info(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        effects = [
          console_effect(char_id, "=== Player Info: #{target.name} ==="),
          console_effect(
            char_id,
            "HP: #{target.hp}/#{target.max_hp} | Mana: #{target.mana}/#{target.max_mana}"
          ),
          console_effect(
            char_id,
            "Level: #{target.level} | Class: #{target.class} | Race: #{target.race}"
          ),
          console_effect(
            char_id,
            "Position: map #{target.map_id} (#{target.x}, #{target.y})"
          ),
          console_effect(char_id, "Gold: #{target.gold} | XP: #{target.xp}"),
          console_effect(
            char_id,
            "Dead: #{target.dead} | Criminal: #{target.criminal} | Invisible: #{target.invisible}"
          )
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state,
         [console_effect(char_id, "Player '#{target_name}' not found on this map.")]}
    end
  end

  def gm_char_stats(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        effects = [
          console_effect(char_id, "=== Stats: #{target.name} ==="),
          console_effect(char_id, "STR: #{target.str} AGI: #{target.agi} INT: #{target.int}"),
          console_effect(char_id, "CON: #{target.con} CHA: #{target.cha}"),
          console_effect(char_id, "Level: #{target.level} XP: #{target.xp}"),
          console_effect(
            char_id,
            "HP: #{target.hp}/#{target.max_hp} Mana: #{target.mana}/#{target.max_mana}"
          ),
          console_effect(char_id, "Stamina: #{target.stamina}/#{target.max_stamina}")
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end

  def gm_char_gold(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        {:ok, state, [console_effect(char_id, "#{target.name} gold: #{target.gold}")]}

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end

  def gm_char_inventory(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        header = console_effect(char_id, "=== Inventory: #{target.name} ===")

        listing =
          target.inventory
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {item, slot} ->
            if item != nil do
              item_def = GameData.get_item(item.item_id)
              name = if item_def, do: item_def.name, else: "?"

              [
                console_effect(
                  char_id,
                  "Slot #{slot}: #{name} (#{item.item_id}) x#{item.amount}"
                )
              ]
            else
              []
            end
          end)

        {:ok, state, [header | listing]}

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end

  def gm_char_bank(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        {:ok, state,
         [
           console_effect(
             char_id,
             "#{target.name} bank gold: #{Map.get(target, :bank_gold, 0)}"
           )
         ]}

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end

  def gm_char_skills(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        header = console_effect(char_id, "=== Skills: #{target.name} ===")

        rows =
          Enum.map(target.skills, fn {skill, level} ->
            console_effect(char_id, "#{skill}: #{level}")
          end)

        {:ok, state, [header | rows]}

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end

  def gm_locate(state, char_id, target_name) do
    case AoSession.OnlineDirectory.lookup_by_name(target_name) do
      {:ok, _target_char_id, info} ->
        {:ok, state,
         [console_effect(char_id, "#{target_name} está en mapa #{info.map_id}")]}

      :not_found ->
        case Helpers.find_player_by_name(state, target_name) do
          {:ok, _target_id, target} ->
            {:ok, state,
             [
               console_effect(
                 char_id,
                 "#{target.name} está en mapa #{state.map_id} (#{target.x}, #{target.y})"
               )
             ]}

          :not_found ->
            {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
        end
    end
  end

  def gm_online_map(state, char_id) do
    names = Enum.map(state.players, fn {_id, entity} -> entity.name end)
    count = length(names)

    {:ok, state,
     [console_effect(char_id, "Jugadores en mapa (#{count}): #{Enum.join(names, ", ")}")]}
  end

  def gm_check_slot(state, char_id, target_name, slot_str) do
    case {Helpers.find_player_by_name(state, target_name), Integer.parse(slot_str)} do
      {{:ok, _target_id, target}, {slot, _}} when slot >= 1 ->
        inventory = Map.get(target, :inventory, %{})

        message =
          case Map.get(inventory, slot) do
            nil ->
              "#{target.name} slot #{slot}: (empty)"

            item ->
              item_def = GameData.get_item(item.item_id)
              name = if item_def, do: item_def.name, else: "?"
              "#{target.name} slot #{slot}: #{name} (#{item.item_id}) x#{item.amount}"
          end

        {:ok, state, [console_effect(char_id, message)]}

      {:not_found, _} ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}

      _ ->
        {:ok, state, [console_effect(char_id, "Invalid slot.")]}
    end
  end

  def gm_creatures_in_map(state, char_id, map_str) do
    case Integer.parse(map_str) do
      {map_id, ""} ->
        if map_id == state.map_id do
          gm_spawn_list(state, char_id)
        else
          {:ok, state,
           [console_effect(char_id, "Cross-map NPC queries are not supported yet.")]}
        end

      _ ->
        {:ok, state, [console_effect(char_id, "Usage: /CREATURES map_id")]}
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

    header = console_effect(char_id, "NPCs on map (#{length(entries)}):")
    rows = Enum.map(entries, &console_effect(char_id, &1))

    {:ok, state, [header | rows]}
  end

  # ── VB6 parity commands ────────────────────────────────────────────────

  @doc "/ONLINE — show online player count (map + server-wide)."
  def gm_online(state, char_id) do
    map_count = map_size(state.players)
    map_effect = console_effect(char_id, "Jugadores en este mapa: #{map_count}")

    server_effect =
      try do
        server_count = AoSession.OnlineDirectory.online_count()
        [console_effect(char_id, "Jugadores online (servidor): #{server_count}")]
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    {:ok, state, [map_effect | server_effect]}
  end

  @doc "/WHERECHAR name — find a character's location with coordinates."
  def gm_wherechar(state, char_id, target_name) do
    # Try local map first
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, _target_id, target} ->
        {:ok, state,
         [
           console_effect(
             char_id,
             "#{target.name} esta en mapa #{state.map_id} (#{target.x}, #{target.y})"
           )
         ]}

      :not_found ->
        message =
          try do
            case AoSession.OnlineDirectory.lookup_by_name(target_name) do
              {:ok, _target_char_id, info} ->
                "#{target_name} esta en mapa #{info.map_id}"

              :not_found ->
                "Player '#{target_name}' not found."
            end
          rescue
            _ -> "Player '#{target_name}' not found."
          catch
            _, _ -> "Player '#{target_name}' not found."
          end

        {:ok, state, [console_effect(char_id, message)]}
    end
  end

  @doc "/IPCHAR name — show a character's account/session info (VB6: shows IP)."
  def gm_ipchar(state, char_id, target_name) do
    case Helpers.find_player_by_name(state, target_name) do
      {:ok, target_id, target} ->
        session_pid = Map.get(state.sessions, target_id)

        effects = [
          console_effect(char_id, "=== Session Info: #{target.name} ==="),
          console_effect(char_id, "Account: #{target.account_id}"),
          console_effect(char_id, "Char ID: #{target_id}"),
          console_effect(char_id, "Session PID: #{inspect(session_pid)}")
        ]

        {:ok, state, effects}

      :not_found ->
        {:ok, state, [console_effect(char_id, "Player '#{target_name}' not found.")]}
    end
  end

  @doc "/SYSTEMINFO — show server system information."
  def gm_system_info(state, char_id) do
    effects =
      try do
        {total_mem, _alloc, _} = :memsup.get_memory_data()
        beam_mem = :erlang.memory(:total)
        schedulers = :erlang.system_info(:schedulers_online)
        process_count = :erlang.system_info(:process_count)
        uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)
        uptime_min = div(uptime_ms, 60_000)

        [
          console_effect(char_id, "=== System Info ==="),
          console_effect(char_id, "BEAM memory: #{div(beam_mem, 1_048_576)} MB"),
          console_effect(char_id, "System memory: #{div(total_mem, 1_048_576)} MB"),
          console_effect(char_id, "Schedulers: #{schedulers}"),
          console_effect(char_id, "Processes: #{process_count}"),
          console_effect(char_id, "Uptime: #{uptime_min} min"),
          console_effect(
            char_id,
            "Map #{state.map_id}: #{map_size(state.players)} players, #{map_size(state.npcs_live)} NPCs"
          )
        ]
      rescue
        # :memsup may not be available in all environments
        _ ->
          beam_mem = :erlang.memory(:total)
          schedulers = :erlang.system_info(:schedulers_online)
          process_count = :erlang.system_info(:process_count)

          [
            console_effect(char_id, "=== System Info ==="),
            console_effect(char_id, "BEAM memory: #{div(beam_mem, 1_048_576)} MB"),
            console_effect(char_id, "Schedulers: #{schedulers}"),
            console_effect(char_id, "Processes: #{process_count}"),
            console_effect(
              char_id,
              "Map #{state.map_id}: #{map_size(state.players)} players, #{map_size(state.npcs_live)} NPCs"
            )
          ]
      end

    {:ok, state, effects}
  end

  ## Internal helpers ────────────────────────────────────────────────────

  defp console_packet(message) do
    Encoder.encode({:console_msg, %{message: message, font_index: 0}})
  end

  defp console_effect(char_id, message) do
    Effects.send(char_id, console_packet(message))
  end
end
