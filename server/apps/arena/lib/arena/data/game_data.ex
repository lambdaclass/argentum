defmodule Arena.Data.GameData do
  @moduledoc """
  Loads static game data from VB6 .dat files into ETS at boot.

  Provides fast lookups for race modifiers, class stats, and city spawn points.
  """

  use GenServer

  require Logger

  alias Arena.Data.IniParser
  alias Arena.Data.ItemDef
  alias Arena.Data.NpcDef
  alias Arena.Data.SpellDef

  @table :arena_game_data

  # Race name mapping (VB6 uses Spanish names in Balance.dat)
  @race_names %{
    1 => :humano,
    2 => :elfo,
    3 => :elfo_oscuro,
    4 => :enano,
    5 => :gnomo,
    6 => :orco
  }

  # Class name mapping (VB6 uses Spanish names in Balance.dat)
  @class_names %{
    1 => :mago,
    2 => :clerigo,
    3 => :paladin,
    4 => :cazador,
    5 => :trabajador,
    6 => :guerrero,
    7 => :ladron,
    8 => :bandido,
    9 => :asesino,
    10 => :druida,
    11 => :bardo,
    12 => :pirata
  }

  # Balance.dat uses these prefixes for race stat modifiers
  @race_prefixes %{
    humano: "humano",
    elfo: "elfo",
    elfo_oscuro: "elfooscuro",
    enano: "enano",
    gnomo: "gnomo",
    orco: "orco"
  }

  @stat_suffixes %{
    str: "fuerza",
    agi: "agilidad",
    int: "inteligencia",
    con: "constitucion",
    cha: "carisma"
  }

  # City name → VB6 section name mapping
  @city_sections %{
    1 => "Ullathorpe",
    2 => "Arghal",
    3 => "NIX",
    4 => "Banderbill",
    5 => "Lindos",
    6 => "Arkhein"
  }

  # Fallback city spawns (from VB6 ConnectNewUser) if Ciudades.Dat missing
  @fallback_city_spawns %{
    1 => %{map: 1, x: 57, y: 45},      # Ullathorpe
    2 => %{map: 151, x: 53, y: 37},     # Arghal
    3 => %{map: 517, x: 49, y: 65},     # Forgat
    4 => %{map: 34, x: 41, y: 87},      # Nix
    5 => %{map: 408, x: 64, y: 40},     # Lindos
    6 => %{map: 59, x: 48, y: 42},      # Banderbill
    7 => %{map: 196, x: 44, y: 59},     # Arkhein
    8 => %{map: 440, x: 51, y: 89},     # Eldoria
    9 => %{map: 560, x: 41, y: 70}      # Penthar
  }

  # ---- Public API ----

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get race attribute modifier. Returns integer."
  def race_mod(race_id, stat) when is_integer(race_id) and stat in [:str, :agi, :int, :con, :cha] do
    case :ets.lookup(@table, {:race_mod, race_id, stat}) do
      [{_, value}] -> value
      [] -> 0
    end
  end

  @doc "Get class HP modifier (per-level HP gain multiplier)."
  def class_hp_mod(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_hp_mod, class_id}) do
      [{_, value}] -> value
      [] -> 8.5
    end
  end

  @doc "Get class initial mana multiplier."
  def class_mana_initial(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_mana_initial, class_id}) do
      [{_, value}] -> value
      [] -> 0.0
    end
  end

  @doc "Get class mana growth multiplier (for leveling)."
  def class_mana_mult(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_mana_mult, class_id}) do
      [{_, value}] -> value
      [] -> 0.0
    end
  end

  @doc "Get class stamina growth factor."
  def class_stamina_growth(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_sta_growth, class_id}) do
      [{_, value}] -> value
      [] -> 15.0
    end
  end

  @doc "Get class skill points per level."
  def class_skill_points(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_skill_pts, class_id}) do
      [{_, value}] -> value
      [] -> 5
    end
  end

  def class_attack_mod(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_attack_mod, class_id}) do
      [{_, value}] -> value
      [] -> 1.0
    end
  end

  def class_damage_mod(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_damage_mod, class_id}) do
      [{_, value}] -> value
      [] -> 1.0
    end
  end

  def class_evasion_mod(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_evasion_mod, class_id}) do
      [{_, value}] -> value
      [] -> 1.0
    end
  end

  def class_shield_mod(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_shield_mod, class_id}) do
      [{_, value}] -> value
      [] -> 1.0
    end
  end

  @doc "VB6: per-class hit modifier for levels 1-36."
  def class_hit_pre36(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_hit_pre36, class_id}) do
      [{_, value}] -> value
      [] -> 1
    end
  end

  @doc "VB6: per-class hit modifier for levels 37+."
  def class_hit_post36(class_id) when is_integer(class_id) do
    case :ets.lookup(@table, {:class_hit_post36, class_id}) do
      [{_, value}] -> value
      [] -> 1
    end
  end

  @doc "Get city spawn point. Returns %{map: int, x: int, y: int}."
  def city_spawn(city_id) when is_integer(city_id) do
    case :ets.lookup(@table, {:city_spawn, city_id}) do
      [{_, value}] -> value
      [] -> Map.get(@fallback_city_spawns, city_id, %{map: 1, x: 50, y: 50})
    end
  end

  @doc "Get race name atom from integer ID."
  def race_name(id), do: Map.get(@race_names, id)

  @doc "Get class name atom from integer ID."
  def class_name(id), do: Map.get(@class_names, id)

  @doc "Get an item definition by ID. Returns nil if not found."
  def get_item(item_id) when is_integer(item_id) do
    case :ets.lookup(@table, {:item, item_id}) do
      [{_, item_def}] -> item_def
      [] -> nil
    end
  end

  @doc "Get spell definition by ID. Returns nil if not found."
  def get_spell(spell_id) when is_integer(spell_id) do
    case :ets.lookup(@table, {:spell, spell_id}) do
      [{_, spell_def}] -> spell_def
      [] -> nil
    end
  end

  @doc "Get spell name by ID. Returns nil if not found."
  def get_spell_name(spell_id) when is_integer(spell_id) do
    case :ets.lookup(@table, {:spell_name, spell_id}) do
      [{_, spell_name}] -> spell_name
      [] -> nil
    end
  end

  @doc "Get NPC definition by ID. Returns nil if not found."
  def get_npc(npc_id) when is_integer(npc_id) do
    case :ets.lookup(@table, {:npc, npc_id}) do
      [{_, npc_def}] -> npc_def
      [] -> nil
    end
  end

  @doc "Get XP threshold associated with a level."
  def exp_for_level(level) when is_integer(level) and level > 0 do
    case :ets.lookup(@table, {:exp_for_level, level}) do
      [{_, exp}] -> exp
      [] -> nil
    end
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    load_balance_dat()
    load_ciudades_dat()
    load_obj_dat()
    load_hechizos_dat()
    load_npcs_dat()

    Logger.info("GameData loaded into ETS (#{:ets.info(table, :size)} entries)")
    {:ok, %{}}
  end

  # ---- Private loaders ----

  defp load_balance_dat do
    path = Path.join(dat_dir(), "Balance.dat")

    case IniParser.parse_file(path) do
      {:ok, sections} ->
        load_race_modifiers(sections)
        load_class_stats(sections)
        load_exp_table(sections)

      {:error, reason} ->
        Logger.warning("Could not load Balance.dat: #{inspect(reason)}. Using defaults.")
    end
  end

  defp load_race_modifiers(sections) do
    modraza = Map.get(sections, "MODRAZA", %{})

    for {race_id, race_atom} <- @race_names do
      prefix = Map.get(@race_prefixes, race_atom, Atom.to_string(race_atom))

      for {stat, suffix} <- @stat_suffixes do
        key = prefix <> suffix
        value = parse_int_or_float(Map.get(modraza, key, "0"))
        :ets.insert(@table, {{:race_mod, race_id, stat}, trunc(value)})
      end
    end
  end

  defp load_class_stats(sections) do
    load_class_section(sections, "MODVIDA", :class_hp_mod, 8.5)
    load_class_section(sections, "MANA_INICIAL", :class_mana_initial, 0.0)
    load_class_section(sections, "MULT_MANA", :class_mana_mult, 0.0)
    load_class_section(sections, "AUMENTO_STA", :class_sta_growth, 15.0)
    load_class_section_int(sections, "MODSKILLPOINTS", :class_skill_pts, 5)
    load_class_section(sections, "MODATAQUEARMAS", :class_attack_mod, 1.0)
    load_class_section(sections, "MODDANOARMAS", :class_damage_mod, 1.0)
    load_class_section(sections, "MODEVASION", :class_evasion_mod, 1.0)
    load_class_section(sections, "MODESCUDO", :class_shield_mod, 1.0)
    # VB6: per-class base hit scaling (Balance.dat GOLPE_PRE_36 / GOLPE_POST_36)
    load_class_section_int(sections, "GOLPE_PRE_36", :class_hit_pre36, 1)
    load_class_section_int(sections, "GOLPE_POST_36", :class_hit_post36, 1)
  end

  defp load_class_section(sections, section_name, ets_prefix, default) do
    section = Map.get(sections, section_name, %{})

    for {class_id, class_atom} <- @class_names do
      key = Atom.to_string(class_atom)
      value = parse_float(Map.get(section, key, to_string(default)))
      :ets.insert(@table, {{ets_prefix, class_id}, value})
    end
  end

  defp load_class_section_int(sections, section_name, ets_prefix, default) do
    section = Map.get(sections, section_name, %{})

    for {class_id, class_atom} <- @class_names do
      key = Atom.to_string(class_atom)
      value = parse_int(Map.get(section, key, to_string(default)))
      :ets.insert(@table, {{ets_prefix, class_id}, value})
    end
  end

  defp load_exp_table(sections) do
    exp_section = Map.get(sections, "EXP", %{})

    exp_section
    |> Enum.each(fn {level_str, exp_str} ->
      case Integer.parse(String.trim(level_str)) do
        {level, _} when level > 0 ->
          :ets.insert(@table, {{:exp_for_level, level}, parse_int(exp_str)})

        _ ->
          :ok
      end
    end)
  end

  defp load_ciudades_dat do
    path = Path.join(dat_dir(), "Ciudades.Dat")

    case IniParser.parse_file(path) do
      {:ok, sections} ->
        for {city_id, section_name} <- @city_sections do
          case Map.get(sections, section_name) do
            nil ->
              # Use fallback
              spawn = Map.get(@fallback_city_spawns, city_id)
              if spawn, do: :ets.insert(@table, {{:city_spawn, city_id}, spawn})

            city ->
              map = parse_int(Map.get(city, "mapa", "1"))
              x = parse_int(Map.get(city, "x", "50"))
              y = parse_int(Map.get(city, "y", "50"))
              :ets.insert(@table, {{:city_spawn, city_id}, %{map: map, x: x, y: y}})
          end
        end

        # Load remaining cities from fallback (Forgat, Nix by number, Eldoria, Penthar)
        for {city_id, spawn} <- @fallback_city_spawns do
          if :ets.lookup(@table, {:city_spawn, city_id}) == [] do
            :ets.insert(@table, {{:city_spawn, city_id}, spawn})
          end
        end

      {:error, reason} ->
        Logger.warning("Could not load Ciudades.Dat: #{inspect(reason)}. Using fallback spawns.")
        for {city_id, spawn} <- @fallback_city_spawns do
          :ets.insert(@table, {{:city_spawn, city_id}, spawn})
        end
    end
  end

  defp load_obj_dat do
    path = Path.join(dat_dir(), "obj.dat")

    case IniParser.parse_file(path) do
      {:ok, sections} ->
        count =
          sections
          |> Enum.reduce(0, fn {section_name, fields}, acc ->
            case Regex.run(~r/^OBJ(\d+)$/i, section_name) do
              [_, id_str] ->
                id = String.to_integer(id_str)
                item_def = ItemDef.from_section(id, fields)
                :ets.insert(@table, {{:item, id}, item_def})
                acc + 1

              _ ->
                acc
            end
          end)

        Logger.info("Loaded #{count} item definitions from obj.dat")

      {:error, reason} ->
        Logger.warning("Could not load obj.dat: #{inspect(reason)}. No item definitions available.")
    end
  end

  defp load_hechizos_dat do
    path = Path.join(dat_dir(), "Hechizos.dat")

    case IniParser.parse_file(path) do
      {:ok, sections} ->
        count =
          sections
          |> Enum.reduce(0, fn {section_name, fields}, acc ->
            case Regex.run(~r/^HECHIZO(\d+)$/i, section_name) do
              [_, id_str] ->
                spell_id = String.to_integer(id_str)
                spell_def = SpellDef.from_section(spell_id, fields)
                :ets.insert(@table, {{:spell, spell_id}, spell_def})
                :ets.insert(@table, {{:spell_name, spell_id}, spell_def.name})
                acc + 1

              _ ->
                acc
            end
          end)

        Logger.info("Loaded #{count} spell definitions from Hechizos.dat")

      {:error, reason} ->
        Logger.warning("Could not load Hechizos.dat: #{inspect(reason)}. No spell data available.")
    end
  end

  defp load_npcs_dat do
    path = Path.join(dat_dir(), "npcs.dat")

    case IniParser.parse_file(path) do
      {:ok, sections} ->
        count =
          sections
          |> Enum.reduce(0, fn {section_name, fields}, acc ->
            case Regex.run(~r/^NPC(\d+)$/i, section_name) do
              [_, id_str] ->
                npc_id = String.to_integer(id_str)
                npc_def = NpcDef.from_section(npc_id, fields)
                :ets.insert(@table, {{:npc, npc_id}, npc_def})
                acc + 1

              _ ->
                acc
            end
          end)

        Logger.info("Loaded #{count} NPC definitions from npcs.dat")

      {:error, reason} ->
        Logger.warning("Could not load npcs.dat: #{inspect(reason)}. No NPC data available.")
    end
  end

  defp parse_int_or_float(str) do
    str = String.trim(str)
    str = if String.starts_with?(str, "+"), do: String.trim_leading(str, "+"), else: str

    case Float.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp parse_float(str) do
    str = String.trim(str)
    str = if String.starts_with?(str, "+"), do: String.trim_leading(str, "+"), else: str

    case Float.parse(str) do
      {val, _} -> val
      :error -> 0.0
    end
  end

  defp parse_int(str) do
    str = String.trim(str)
    str = if String.starts_with?(str, "+"), do: String.trim_leading(str, "+"), else: str

    case Integer.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp dat_dir do
    Application.get_env(:arena, :dat_dir, "../resources/raw/Dat")
  end
end
