defmodule Arena.Data.ItemDef do
  @moduledoc """
  Struct for a parsed item definition from obj.dat.
  """

  defstruct [
    :id,
    :name,
    :obj_type,
    :grh_index,
    valor: 0,
    peso: 0,
    min_hit: 0,
    max_hit: 0,
    min_def: 0,
    max_def: 0,
    min_elv: 0,
    min_ham: 0,
    min_sed: 0,
    tipo_pocion: 0,
    min_modificador: 0,
    max_modificador: 0,
    porcentaje: 0,
    max_elv: 0,
    dos_manos: false,
    newbie: false,
    stackable: false,
    equip_slot: nil,
    forbidden_classes: nil,
    allowed_races: nil,
    gender_restriction: :any,
    destruye: false,
    proyectil: 0,
    municion_type: 0,
    intirable: true,
    instransferible: false,
    staff_power: 0,
    staff_damage_bonus: 0,
    weapon_type: 0,
    puntos_pesca: 0,
    real: false,
    caos: false,
    ropaje: nil,
    elemental_tags: 0
  ]

  @stackable_types [1, 5, 11, 13, 32, 33, 34]

  @equip_slots %{
    2 => :weapon,
    3 => :armor,
    11 => :municion,
    16 => :shield,
    17 => :helmet,
    35 => :ring
  }

  @race_key_map %{
    "razadrow" => :elfo_oscuro,
    "razaelfa" => :elfo,
    "razahumana" => :humano,
    "razaorca" => :orco,
    "razaenana" => :enano,
    "razagnoma" => :gnomo
  }

  @doc "Build an ItemDef from a parsed INI section (downcased keys)."
  def from_section(id, section) do
    obj_type = parse_int(section["objtype"])

    %__MODULE__{
      id: id,
      name: section["name"] || "Unknown",
      obj_type: obj_type,
      grh_index: parse_int(section["grhindex"]),
      valor: parse_int(section["valor"]),
      peso: parse_int(section["peso"]),
      min_hit: parse_int(section["minhit"]),
      max_hit: parse_int(section["maxhit"]),
      min_def: parse_int(section["mindef"]),
      max_def: parse_int(section["maxdef"]),
      min_elv: parse_int(section["minelv"]),
      max_elv: parse_int(section["maxelv"]),
      dos_manos: parse_int(section["dosmanos"]) == 1,
      newbie: parse_int(section["newbie"]) == 1,
      min_ham: parse_int(section["minham"]),
      min_sed: parse_int(section["minsed"]),
      tipo_pocion: parse_int(section["tipopocion"]),
      min_modificador: parse_int(section["minmodificador"]),
      max_modificador: parse_int(section["maxmodificador"]),
      porcentaje: parse_int(section["porcentaje"]),
      stackable: obj_type in @stackable_types,
      equip_slot: Map.get(@equip_slots, obj_type),
      forbidden_classes: parse_forbidden_classes(section),
      allowed_races: parse_allowed_races(section),
      gender_restriction: parse_gender(section),
      destruye: parse_int(section["destruye"]) == 1,
      proyectil: parse_int(section["proyectil"]),
      municion_type: parse_int(section["municiontype"]),
      intirable: section["intirable"] == nil or parse_int(section["intirable"]) != 0,
      instransferible: parse_int(section["instransferible"]) == 1,
      staff_power: parse_int(section["staffpower"]),
      staff_damage_bonus: parse_int(section["staffdamagebonus"]),
      weapon_type: parse_int(section["weapontype"]),
      puntos_pesca: parse_int(section["puntospesca"]),
      real: parse_int(section["real"]) == 1,
      caos: parse_int(section["caos"]) == 1,
      ropaje: parse_ropaje(section),
      elemental_tags: parse_int(section["elementaltags"])
    }
  end

  defp parse_int(nil), do: 0

  defp parse_int(str) do
    str = String.trim(str)

    case Integer.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end

  # CP1..CP12 list forbidden class names
  defp parse_forbidden_classes(section) do
    classes =
      for i <- 1..12,
          val = section["cp#{i}"],
          val != nil,
          into: MapSet.new() do
        String.downcase(val)
      end

    if MapSet.size(classes) == 0, do: nil, else: classes
  end

  # Raza* keys list allowed races; nil means all allowed
  defp parse_allowed_races(section) do
    allowed =
      for {key, race_atom} <- @race_key_map,
          section[key] != nil,
          into: MapSet.new() do
        race_atom
      end

    if MapSet.size(allowed) == 0, do: nil, else: allowed
  end

  defp parse_gender(section) do
    cond do
      parse_int(section["mujer"]) == 1 -> :female
      parse_int(section["hombre"]) == 1 -> :male
      true -> :any
    end
  end

  @ropaje_keys [
    {"ropajehumano", :humano_m},
    {"ropajehumana", :humano_f},
    {"ropajeelfo", :elfo_m},
    {"ropajeelfa", :elfo_f},
    {"ropajeelfooscuro", :elfo_oscuro_m},
    {"ropajeelfaoscura", :elfo_oscuro_f},
    {"ropajeenano", :enano_m},
    {"ropajeenana", :enano_f},
    {"ropajeorco", :orco_m},
    {"ropajeorca", :orco_f},
    {"ropajegnomo", :gnomo_m},
    {"ropajegnoma", :gnomo_f},
    # Alternate underscore-separated keys (used in some obj.dat variants)
    {"ropaje_humano_m", :humano_m},
    {"ropaje_humano_f", :humano_f},
    {"ropaje_elfo_m", :elfo_m},
    {"ropaje_elfo_f", :elfo_f},
    {"ropaje_elfo_oscuro_m", :elfo_oscuro_m},
    {"ropaje_elfo_oscuro_f", :elfo_oscuro_f},
    {"ropaje_enano_m", :enano_m},
    {"ropaje_enano_f", :enano_f},
    {"ropaje_orco_m", :orco_m},
    {"ropaje_orco_f", :orco_f},
    {"ropaje_gnomo_m", :gnomo_m},
    {"ropaje_gnomo_f", :gnomo_f}
  ]

  defp parse_ropaje(section) do
    ropaje =
      for {raw_key, atom_key} <- @ropaje_keys,
          val = parse_int(section[raw_key]),
          val != 0,
          into: %{} do
        {atom_key, val}
      end

    if map_size(ropaje) == 0, do: nil, else: ropaje
  end
end
